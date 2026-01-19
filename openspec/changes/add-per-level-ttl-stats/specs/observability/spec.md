# Observability - Per-Level TTL Statistics

## ADDED Requirements

### Requirement: Per-Level Total Bytes Metric

The system SHALL expose estimated total bytes per LSM level for capacity planning.

#### Scenario: Total bytes metric definition

- **WHEN** exposing level byte metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_lsm_bytes_by_level Estimated total bytes per LSM level
  # TYPE archerdb_lsm_bytes_by_level gauge
  archerdb_lsm_bytes_by_level{level="1"} 1073741824
  archerdb_lsm_bytes_by_level{level="2"} 8589934592
  archerdb_lsm_bytes_by_level{level="3"} 68719476736
  archerdb_lsm_bytes_by_level{level="4"} 549755813888
  archerdb_lsm_bytes_by_level{level="5"} 4398046511104
  archerdb_lsm_bytes_by_level{level="6"} 35184372088832
  ```
- **AND** values SHALL be in bytes (not KB, MB, or GB)
- **AND** level 0 SHALL always report 0 (excluded from tracking)

#### Scenario: Total bytes metric update

- **WHEN** a compaction bar completes
- **THEN** the metric for the target level SHALL be updated
- **AND** updates SHALL use EMA-smoothed estimates from level statistics

### Requirement: Per-Level Expired Bytes Metric

The system SHALL expose estimated expired bytes per LSM level for capacity planning and alerting.

#### Scenario: Expired bytes metric definition

- **WHEN** exposing TTL expired byte metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_ttl_expired_bytes_by_level Estimated expired bytes per LSM level
  # TYPE archerdb_ttl_expired_bytes_by_level gauge
  archerdb_ttl_expired_bytes_by_level{level="1"} 53687091
  archerdb_ttl_expired_bytes_by_level{level="2"} 1073741824
  archerdb_ttl_expired_bytes_by_level{level="3"} 30923764531
  archerdb_ttl_expired_bytes_by_level{level="4"} 153896461312
  archerdb_ttl_expired_bytes_by_level{level="5"} 2638827906662
  archerdb_ttl_expired_bytes_by_level{level="6"} 12314656071065
  ```
- **AND** values SHALL be in bytes
- **AND** level 0 SHALL always report 0 (excluded from tracking)

#### Scenario: Expired bytes metric accuracy

- **WHEN** interpreting the expired bytes metric
- **THEN** operators SHALL understand:
  - Values are **estimates** based on sampling during compaction
  - Expected accuracy: within 20% of actual expired bytes
  - Accuracy improves as more tables are compacted
  - `expired_bytes / total_bytes ≈ expired_ratio` (within 10%)

#### Scenario: Initial metric state on startup

- **WHEN** ArcherDB starts (fresh or restart)
- **THEN** all byte metrics SHALL be 0
- **AND** values SHALL converge to actual estimates within 2-3 compaction cycles

### Requirement: Capacity Planning Alerts

The system SHALL support alerting on absolute byte thresholds for capacity planning.

#### Scenario: Alerting on expired bytes accumulation

- **WHEN** configuring monitoring alerts
- **THEN** operators MAY set alerts based on absolute bytes:
  ```yaml
  Alert: TTL expired data accumulation
  Condition: sum(archerdb_ttl_expired_bytes_by_level) > 107374182400  # 100GB
  Severity: Warning
  Message: >100GB of expired data accumulated, compaction may be falling behind
  ```
- **AND** this enables cost-based alerting (e.g., "alert if wasted storage exceeds $X")

#### Scenario: Disk usage correlation

- **WHEN** analyzing disk usage
- **THEN** operators MAY use:
  ```promql
  # Total estimated LSM data
  sum(archerdb_lsm_bytes_by_level)

  # Estimated reclaimable space (expired data)
  sum(archerdb_ttl_expired_bytes_by_level)

  # Percentage of data that is expired (cluster-wide)
  sum(archerdb_ttl_expired_bytes_by_level) / sum(archerdb_lsm_bytes_by_level)
  ```
- **AND** these queries enable capacity planning dashboards

#### Scenario: Per-level disk usage breakdown

- **WHEN** operators need level-specific insights
- **THEN** they MAY query:
  ```promql
  # Which level has the most expired data?
  topk(1, archerdb_ttl_expired_bytes_by_level)

  # Level 5 expired percentage
  archerdb_ttl_expired_bytes_by_level{level="5"} /
  archerdb_lsm_bytes_by_level{level="5"}

  # Verify consistency with ratio metric
  archerdb_ttl_expired_bytes_by_level / archerdb_lsm_bytes_by_level
  ≈ archerdb_ttl_expired_ratio_by_level  # Should be within 10%
  ```

## MODIFIED Requirements

### Requirement: TTL Metrics Consistency (Modified)

Extends existing TTL metrics to ensure consistency between ratio and byte metrics.

#### Scenario: Ratio and byte metric consistency

- **WHEN** both ratio and byte metrics are exposed
- **THEN** the following relationship SHALL hold approximately:
  ```
  archerdb_ttl_expired_bytes_by_level{level="N"} /
  archerdb_lsm_bytes_by_level{level="N"}
  ≈ archerdb_ttl_expired_ratio_by_level{level="N"}
  ```
- **AND** discrepancy SHALL be within 10% (due to independent EMA smoothing)
- **AND** operators SHOULD use ratio for compaction prioritization insights
- **AND** operators SHOULD use bytes for capacity planning and cost analysis

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Per-Level Total Bytes Metric | IMPLEMENTED | `src/archerdb/metrics.zig` - `archerdb_lsm_bytes_by_level` gauge |
| Per-Level Expired Bytes Metric | IMPLEMENTED | `src/archerdb/metrics.zig` - `archerdb_lsm_ttl_expired_bytes_by_level` gauge |
| Capacity Planning Alerts | IMPLEMENTED | Prometheus-compatible metrics support alerting |
| TTL Metrics Consistency (Modified) | IMPLEMENTED | Ratio and bytes metrics updated consistently via EMA |

## Related Specifications

- Depends on: `add-ttl-aware-compaction/specs/observability/spec.md` for expired_ratio metric
- See `storage-engine/spec.md` (this change) for byte tracking implementation
- See base `observability/spec.md` for Prometheus endpoint configuration
