# Observability - TTL-Aware Compaction

## ADDED Requirements

### Requirement: TTL Expired Ratio Metric

The system SHALL expose a metric tracking the estimated expired data ratio per LSM level.

#### Scenario: Metric definition

- **WHEN** exposing TTL expired ratio metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_ttl_expired_ratio_by_level Estimated expired data ratio per LSM level (0.0-1.0)
  # TYPE archerdb_ttl_expired_ratio_by_level gauge
  archerdb_ttl_expired_ratio_by_level{level="1"} 0.05
  archerdb_ttl_expired_ratio_by_level{level="2"} 0.12
  archerdb_ttl_expired_ratio_by_level{level="3"} 0.45
  archerdb_ttl_expired_ratio_by_level{level="4"} 0.28
  archerdb_ttl_expired_ratio_by_level{level="5"} 0.61
  archerdb_ttl_expired_ratio_by_level{level="6"} 0.35
  ```
- **AND** the metric SHALL be updated after each compaction bar completes
- **AND** values SHALL be in range [0.0, 1.0] where:
  - 0.0 = no expired data
  - 1.0 = all data expired

#### Scenario: Metric accuracy

- **WHEN** interpreting the expired ratio metric
- **THEN** operators SHALL understand:
  - Values are **estimates** based on sampling during compaction
  - Accuracy improves over time as tables are compacted
  - Newly created levels start at 0.0 until first compaction
  - Values use exponential moving average (recent samples weighted higher)

#### Scenario: Initial metric state on startup

- **WHEN** ArcherDB starts (fresh or restart)
- **THEN** all `archerdb_ttl_expired_ratio_by_level` values SHALL be 0.0
- **AND** level 0 SHALL always report 0.0 (excluded from tracking)
- **AND** values SHALL converge to actual ratios within 2-3 compaction cycles

#### Scenario: Alerting on high expired ratios

- **WHEN** configuring monitoring alerts
- **THEN** operators MAY set alerts:
  ```
  Alert: TTL accumulation warning
  Condition: archerdb_ttl_expired_ratio_by_level{level=~"[456]"} > 0.5
  Severity: Warning
  Message: Level {level} has >50% expired data, compaction prioritization active
  ```
- **AND** high ratios (>50%) indicate significant expired accumulation
- **AND** values >80% MAY indicate TTL cliff or bulk expiration event

### Requirement: TTL Compaction Prioritization Events

The system SHALL log events when TTL-based compaction prioritization occurs.

#### Scenario: Log level prioritization

- **WHEN** a level is prioritized due to high expired ratio
- **THEN** the system SHALL log at INFO level:
  ```
  info: TTL-prioritized level {level} (expired_ratio={ratio:.2}, threshold={threshold:.2}, op={op})
  ```
- **AND** the log SHALL include:
  - `level`: The LSM level being prioritized (1-6, level 0 excluded)
  - `ratio`: Current expired_ratio for the level
  - `threshold`: Configured ttl_priority_threshold
  - `op`: Operation number when prioritization occurred

#### Scenario: Log compaction bar statistics

- **WHEN** a compaction bar completes
- **THEN** the system SHALL log at DEBUG level:
  ```
  Compaction bar complete: level={level} values_total={total} values_expired={expired} expired_ratio_sample={ratio:.3}
  ```
- **AND** this provides visibility into sampling data
- **AND** operators can correlate with metric updates

## MODIFIED Requirements

### Requirement: Compaction Metrics (Modified)

Extends existing compaction metrics to include TTL-specific tracking.

#### Scenario: Existing metrics unchanged

- **WHEN** exposing compaction metrics
- **THEN** all existing metrics SHALL continue to function:
  - `archerdb_compaction_tables_input_total`
  - `archerdb_compaction_tables_output_total`
  - `archerdb_compaction_values_total`
  - `archerdb_compaction_disk_bytes_read_total`
  - `archerdb_compaction_disk_bytes_written_total`
- **AND** these metrics SHALL NOT be affected by TTL prioritization

#### Scenario: Compaction debt ratio interaction

- **WHEN** TTL prioritization is active
- **THEN** `archerdb_compaction_debt_ratio` SHALL:
  - Continue tracking overall compaction backlog
  - Decrease faster for TTL-heavy levels (due to prioritization)
  - Remain accurate for capacity planning
- **AND** operators MAY use both metrics together:
  - `compaction_debt_ratio`: Overall LSM health
  - `ttl_expired_ratio_by_level`: TTL-specific accumulation

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| TTL Expired Ratio Metric | IMPLEMENTED | `src/archerdb/metrics.zig` - `archerdb_ttl_expired_ratio_by_level` gauge per level |
| TTL Compaction Prioritization Events | IMPLEMENTED | `src/lsm/compaction.zig` - INFO and DEBUG level logging |
| Compaction Metrics (Modified) | IMPLEMENTED | `src/archerdb/metrics.zig` - Extended compaction metrics |

## Related Specifications

- See `storage-engine/spec.md` (this change) for expired ratio tracking and scheduling logic
- See base `observability/spec.md` for existing compaction metrics
- See `ttl-retention/spec.md` for TTL expiration behavior during compaction
