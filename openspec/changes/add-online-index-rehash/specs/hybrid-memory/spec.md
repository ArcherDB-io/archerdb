# Hybrid Memory - Online Index Rehash

## ADDED Requirements

### Requirement: Online Index Resize

The system SHALL support resizing the RAM index hash table without stopping database operations.

#### Scenario: Resize initiation

- **WHEN** operator initiates resize via CLI
- **THEN** the system SHALL:
  - Validate new_capacity > current_capacity
  - Check available memory >= 2x current index size
  - Allocate new hash table
  - Start background migration
  - Transition to `resizing` state
- **AND** queries SHALL continue without interruption

#### Scenario: Resize state machine

- **WHEN** resize is in progress
- **THEN** the system SHALL maintain state:
  ```zig
  state: enum { normal, resizing, completing }
  ```
- **AND** transitions SHALL be:
  - `normal` → `resizing` on resize command
  - `resizing` → `completing` when all entries migrated
  - `completing` → `normal` after old table freed

#### Scenario: Resize rejection

- **WHEN** resize is requested with invalid parameters
- **THEN** the system SHALL reject with error:
  - `new_capacity <= current_capacity`: "New capacity must exceed current"
  - `insufficient memory`: "Insufficient memory for resize (need Xgb, have Ygb)"
  - `already resizing`: "Resize already in progress"

### Requirement: Dual-Table Lookup

The system SHALL support concurrent queries during resize by checking both tables.

#### Scenario: Lookup during resize

- **WHEN** lookup is performed during resize
- **THEN** the system SHALL:
  1. Search active (new) table first
  2. If not found and resizing, search old table
  3. If found in old table, migrate entry to new table
  4. Return entry from new table

#### Scenario: Lookup performance

- **WHEN** entry is found in old table
- **THEN** the system SHALL migrate it inline
- **AND** subsequent lookups SHALL find it in new table
- **AND** hot entries migrate quickly due to access patterns

### Requirement: Dual-Table Upsert

The system SHALL support writes during resize by targeting the new table.

#### Scenario: Upsert during resize

- **WHEN** upsert is performed during resize
- **THEN** the system SHALL:
  1. Insert/update entry in active (new) table
  2. Mark corresponding entry in old table as migrated
  3. Update statistics
- **AND** no data SHALL be lost

#### Scenario: Tombstone handling during resize

- **WHEN** entity is deleted during resize
- **THEN** the system SHALL:
  - Create tombstone in new table
  - Mark old table entry as migrated
- **AND** lookup SHALL return null for deleted entity

### Requirement: Background Migration

The system SHALL migrate entries in the background to complete resize.

#### Scenario: Background sweeper

- **WHEN** resize is in progress
- **THEN** a background thread SHALL:
  - Scan old table for unmigrated entries
  - Migrate entries in batches (default: 1000)
  - Sleep between batches (default: 1ms)
  - Track progress via atomic counter
- **AND** sweeper SHALL NOT block query operations

#### Scenario: Migration rate limiting

- **WHEN** background migration runs
- **THEN** the system SHALL:
  - Limit CPU usage (default: 10% max)
  - Yield to query operations
  - Adjust batch size based on load
- **AND** latency impact SHALL be <10%

#### Scenario: Migration completion

- **WHEN** all entries are migrated
- **THEN** the system SHALL:
  - Verify migration count equals original entry count
  - Free old table memory
  - Transition to `normal` state
  - Log completion event
- **AND** the system SHALL expose metric:
  ```
  archerdb_index_resize_completed_total 1
  ```

### Requirement: Resize CLI Commands

The system SHALL provide CLI commands for resize operations.

#### Scenario: Resize check command

- **WHEN** operator runs `archerdb index resize --check`
- **THEN** the system SHALL output:
  ```
  Current capacity: 1,000,000,000
  Current entries:    750,000,000 (75% load)
  New capacity:     2,000,000,000
  Memory required:    ~128GB (current ~64GB)
  Available RAM:      256GB
  Status: SAFE TO PROCEED
  ```

#### Scenario: Resize start command

- **WHEN** operator runs `archerdb index resize --new-capacity=N`
- **THEN** the system SHALL:
  - Perform safety checks
  - Start resize operation
  - Output: "Resize started. Progress: 0%"
- **AND** return exit code 0 on success

#### Scenario: Resize status command

- **WHEN** operator runs `archerdb index resize --status`
- **THEN** the system SHALL output:
  ```
  State: RESIZING
  Progress: 45% (450,000,000 / 1,000,000,000 entries)
  Elapsed: 5m 32s
  Estimated remaining: 6m 45s
  ```

#### Scenario: Resize abort command

- **WHEN** operator runs `archerdb index resize --abort`
- **THEN** the system SHALL:
  - Stop background sweeper
  - Complete or rollback based on progress
  - If <50% migrated: rollback to old table
  - If >=50% migrated: complete migration
- **AND** log abort event with reason

### Requirement: Resize Metrics

The system SHALL expose metrics for resize monitoring.

#### Scenario: Resize state metric

- **WHEN** resize is in progress
- **THEN** the system SHALL expose:
  ```
  # HELP archerdb_index_resize_state Current resize state (0=normal, 1=resizing, 2=completing)
  # TYPE archerdb_index_resize_state gauge
  archerdb_index_resize_state 1
  ```

#### Scenario: Resize progress metric

- **WHEN** resize is in progress
- **THEN** the system SHALL expose:
  ```
  # HELP archerdb_index_resize_progress Resize progress (0.0 to 1.0)
  # TYPE archerdb_index_resize_progress gauge
  archerdb_index_resize_progress 0.45

  # HELP archerdb_index_resize_entries_migrated Total entries migrated
  # TYPE archerdb_index_resize_entries_migrated counter
  archerdb_index_resize_entries_migrated 450000000
  ```

#### Scenario: Resize duration metric

- **WHEN** resize completes
- **THEN** the system SHALL expose:
  ```
  # HELP archerdb_index_resize_duration_seconds Time spent on last resize
  # TYPE archerdb_index_resize_duration_seconds gauge
  archerdb_index_resize_duration_seconds 732.5
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Online Index Resize | IMPLEMENTED | `src/ram_index.zig` - startResize(), ResizeState machine |
| Dual-Table Lookup | IMPLEMENTED | `src/ram_index.zig` - lookupWithMigration() checks both tables |
| Dual-Table Upsert | IMPLEMENTED | `src/ram_index.zig` - Upserts target new table during resize |
| Background Migration | IMPLEMENTED | `src/ram_index.zig` - sweeper thread with rate limiting |
| Resize CLI Commands | IMPLEMENTED | `src/archerdb/cli.zig` - index resize, status, abort commands |
| Resize Metrics | IMPLEMENTED | `src/archerdb/metrics.zig` - resize state, progress, duration metrics |

## Related Specifications

- See base `hybrid-memory/spec.md` for IndexEntry definition
- See `configuration/spec.md` for CLI framework
- See `observability/spec.md` for metrics endpoint
