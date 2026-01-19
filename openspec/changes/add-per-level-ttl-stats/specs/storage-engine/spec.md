# Storage Engine - Per-Level TTL Statistics

## MODIFIED Requirements

### Requirement: Compaction Bar Statistics (Modified)

Extends the TTL-aware compaction bar statistics to include byte counts.

#### Scenario: Bar statistics include byte counts

- **WHEN** a compaction bar processes values
- **THEN** `BarStatistics` SHALL include:
  - `values_total: u64` (existing)
  - `values_expired: u64` (existing from add-ttl-aware-compaction)
  - `bytes_total: u64` (NEW - total bytes of values processed)
  - `bytes_expired: u64` (NEW - bytes of expired values discarded)
- **AND** byte counts SHALL use the serialized size of each value (128 bytes for GeoEvent)

#### Scenario: Byte counting during value iteration

- **WHEN** compaction iterates over values in a bar
- **THEN** for each value processed:
  - `bar.stats.bytes_total += value_byte_size`
  - If value is expired: `bar.stats.bytes_expired += value_byte_size`
- **AND** `value_byte_size` SHALL be the on-disk size of the value (128 bytes for GeoEvent)

### Requirement: Per-Level Byte Estimates (New)

The system SHALL maintain estimated byte counts per LSM level via sampling during compaction.

#### Scenario: Level byte estimate fields

- **WHEN** tracking level statistics
- **THEN** each level SHALL maintain:
  - `estimated_total_bytes: u64` - Estimated total bytes in level
  - `estimated_expired_bytes: u64` - Estimated expired bytes in level
- **AND** these fields SHALL be updated after each compaction bar completes

#### Scenario: Update byte estimates with EMA

- **WHEN** a compaction bar completes for level B
- **AND** `values_total > 0`
- **THEN** the system SHALL update byte estimates:
  ```
  alpha = 0.2  # Same as expired_ratio (compile-time constant)
  scale = level_table_count  # Extrapolate from sample to level

  sample_total_bytes = bytes_total × scale
  level.estimated_total_bytes = alpha × sample_total_bytes + (1 - alpha) × level.estimated_total_bytes

  sample_expired_bytes = bytes_expired × scale
  level.estimated_expired_bytes = alpha × sample_expired_bytes + (1 - alpha) × level.estimated_expired_bytes
  ```
- **AND** the EMA SHALL smooth byte estimates over multiple compaction bars

#### Scenario: Initial byte estimates

- **WHEN** a level has never been compacted
- **THEN** `estimated_total_bytes` SHALL be 0
- **AND** `estimated_expired_bytes` SHALL be 0
- **AND** estimates SHALL converge after 2-3 compaction cycles

#### Scenario: Byte estimates on process restart

- **WHEN** the ArcherDB process restarts
- **THEN** all byte estimate values SHALL reset to 0
- **AND** estimates SHALL NOT be persisted to superblock (runtime-only)
- **AND** estimates will reconverge after 2-3 compaction cycles per level

#### Scenario: Byte estimate accuracy expectation

- **WHEN** interpreting byte estimates
- **THEN** operators SHALL understand:
  - Values are **estimates** based on sampling during compaction
  - Accuracy improves as more tables are compacted
  - Expected accuracy: within 20% of actual disk usage
  - `estimated_expired_bytes / estimated_total_bytes ≈ expired_ratio`

#### Scenario: Level 0 byte estimates

- **WHEN** tracking byte estimates
- **THEN** level 0 SHALL be excluded (same as expired_ratio tracking)
- **AND** level 0 estimated bytes SHALL always be 0
- **BECAUSE** level 0 contains immutable tables that flush directly from memory

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Compaction Bar Statistics (Modified) | IMPLEMENTED | `src/lsm/compaction.zig` - bytes_total, bytes_expired tracking |
| Per-Level Byte Estimates (New) | IMPLEMENTED | `src/lsm/manifest_level.zig` - estimated_total_bytes, estimated_expired_bytes |

## Related Specifications

- Depends on: `add-ttl-aware-compaction/specs/storage-engine/spec.md` for sampling infrastructure
- See `observability/spec.md` (this change) for byte metrics exposure
- See base `storage-engine/spec.md` for compaction mechanics
