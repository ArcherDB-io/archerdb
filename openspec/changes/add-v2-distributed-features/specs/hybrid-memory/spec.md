# Hybrid Memory v2 Spec Deltas

## ADDED Requirements

### Requirement: Hot-Warm-Cold Data Tiering

The system SHALL support automatic tiering of data based on access patterns to optimize cost and performance.

#### Scenario: Tier definitions

- **WHEN** data tiering is enabled
- **THEN** the system SHALL maintain three tiers:
  | Tier | Storage | Latency SLA | Cost | Use Case |
  |------|---------|-------------|------|----------|
  | Hot | NVMe + RAM Index | <1ms | $$$ | Active entities |
  | Warm | NVMe LSM only | <10ms | $$ | Recent history |
  | Cold | S3-compatible | <5s | $ | Archive/compliance |
- **AND** tier boundaries SHALL be configurable per deployment

#### Scenario: Tier assignment policy

- **WHEN** determining entity tier placement
- **THEN** the system SHALL use access-based policy:
  - **Hot**: Accessed within `hot_threshold` (default: 7 days)
  - **Warm**: Accessed within `warm_threshold` (default: 30 days)
  - **Cold**: Not accessed within `warm_threshold`
- **AND** write operations SHALL reset access timestamp
- **AND** read operations SHALL reset access timestamp (touch on read)

#### Scenario: Tier configuration

- **WHEN** configuring tiering
- **THEN** operators SHALL specify:
  ```
  --tiering-enabled=true
  --tiering-hot-threshold=7d
  --tiering-warm-threshold=30d
  --tiering-cold-storage=s3://bucket/prefix
  --tiering-migration-rate=1000  # entities per second
  ```
- **AND** tiering MAY be enabled on existing deployments

### Requirement: Automatic Tier Migration

The system SHALL automatically migrate data between tiers based on access patterns.

#### Scenario: Hot to warm migration

- **WHEN** an entity's last access exceeds hot_threshold
- **THEN** the system SHALL:
  - Remove entity from RAM index
  - Retain entity data in LSM (already present)
  - Update tier metadata
  - Increment `archerdb_tiering_demotions_total{from="hot",to="warm"}`
- **AND** migration SHALL be batched for efficiency

#### Scenario: Warm to cold migration

- **WHEN** an entity's last access exceeds warm_threshold
- **THEN** the system SHALL:
  - Export entity data to cold storage (S3)
  - Remove entity from local LSM after confirmed upload
  - Store cold tier pointer in metadata index
  - Increment `archerdb_tiering_demotions_total{from="warm",to="cold"}`
- **AND** cold upload SHALL be retried on failure

#### Scenario: Cold to warm promotion

- **WHEN** a cold tier entity is accessed
- **THEN** the system SHALL:
  - Fetch entity data from cold storage
  - Import into local LSM
  - Update access timestamp
  - Serve query (with higher latency this request)
  - Increment `archerdb_tiering_promotions_total{from="cold",to="warm"}`
- **AND** subsequent accesses SHALL be from warm tier

#### Scenario: Warm to hot promotion

- **WHEN** a warm tier entity is accessed frequently
- **THEN** the system SHALL:
  - Add entity to RAM index
  - Update access timestamp
  - Increment `archerdb_tiering_promotions_total{from="warm",to="hot"}`
- **AND** promotion SHALL occur after `hot_promotion_threshold` accesses (default: 3)

### Requirement: Migration Rate Limiting

The system SHALL rate-limit tier migrations to avoid impacting production workloads.

#### Scenario: Migration rate configuration

- **WHEN** configuring migration rate
- **THEN** operators SHALL specify:
  - `--tiering-migration-rate`: Max entities per second (default: 1000)
  - `--tiering-migration-window`: Time window for migrations (default: "02:00-06:00")
  - `--tiering-migration-priority`: Background priority (default: low)
- **AND** migrations outside window SHALL be paused

#### Scenario: Migration backpressure

- **WHEN** migration queue exceeds threshold
- **THEN** the system SHALL:
  - Log warning about migration backlog
  - Expose `archerdb_tiering_queue_depth` metric
  - NOT block writes or reads
  - Continue serving with entities in suboptimal tiers
- **AND** backlog SHALL be cleared during migration windows

#### Scenario: Migration storm prevention

- **WHEN** many entities become eligible for demotion simultaneously
- **THEN** the system SHALL:
  - Spread migrations over time (jitter)
  - Prioritize oldest-access entities first
  - Cap daily migration volume to 1% of hot tier
- **AND** storm prevention SHALL be logged for observability

### Requirement: Cold Tier Storage

The system SHALL support S3-compatible object storage for cold tier data.

#### Scenario: Cold storage configuration

- **WHEN** configuring cold storage
- **THEN** operators SHALL specify:
  ```
  --tiering-cold-storage=s3://bucket/prefix
  --tiering-cold-region=us-west-2
  --tiering-cold-storage-class=GLACIER_IR  # or STANDARD, INTELLIGENT_TIERING
  ```
- **AND** credentials SHALL use IAM roles or explicit keys

#### Scenario: Cold storage object format

- **WHEN** storing entities in cold tier
- **THEN** objects SHALL be organized as:
  ```
  s3://bucket/prefix/
  ├── entities/
  │   ├── 00/  # First 2 hex digits of entity_id
  │   │   ├── 00/  # Next 2 hex digits
  │   │   │   └── <entity_id>.bin  # Entity data
  │   │   └── ...
  │   └── ...
  └── manifests/
      └── YYYY-MM-DD/
          └── migration-<timestamp>.json
  ```
- **AND** objects SHALL be encrypted if encryption enabled

#### Scenario: Cold tier query latency

- **WHEN** querying cold tier entities
- **THEN** the system SHALL:
  - Return within 5 seconds (p99) for single entity
  - Support batch prefetch for anticipated access
  - Expose `archerdb_cold_tier_latency_seconds` histogram
- **AND** cold tier latency SHALL be documented as expected behavior

### Requirement: Tiering Observability

The system SHALL expose metrics for monitoring tier distribution and migration.

#### Scenario: Tier distribution metrics

- **WHEN** exposing tiering metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_tier_entity_count{tier="hot"} 100000000
  archerdb_tier_entity_count{tier="warm"} 500000000
  archerdb_tier_entity_count{tier="cold"} 400000000

  archerdb_tier_size_bytes{tier="hot"} 12800000000
  archerdb_tier_size_bytes{tier="warm"} 64000000000
  archerdb_tier_size_bytes{tier="cold"} 51200000000
  ```

#### Scenario: Migration metrics

- **WHEN** exposing migration metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_tiering_migrations_total{direction="demotion",from="hot",to="warm"} 1000000
  archerdb_tiering_migrations_total{direction="promotion",from="cold",to="warm"} 50000

  archerdb_tiering_queue_depth{direction="demotion"} 5000
  archerdb_tiering_migration_rate 950  # current entities/sec
  archerdb_tiering_migration_errors_total{reason="s3_timeout"} 10
  ```

#### Scenario: Cost metrics

- **WHEN** tracking storage costs
- **THEN** the system SHALL provide:
  ```
  archerdb_tier_estimated_cost_usd{tier="hot"} 1500.00
  archerdb_tier_estimated_cost_usd{tier="warm"} 800.00
  archerdb_tier_estimated_cost_usd{tier="cold"} 50.00
  ```
- **AND** cost calculation SHALL use configurable $/GB rates

## ADDED Error Codes

### Requirement: Tiering Error Codes

The system SHALL define error codes for tiering operations.

#### Scenario: New tiering error codes

- **WHEN** tiering errors occur
- **THEN** the following error codes SHALL be used:
  | Code | Name | Message | Retry |
  |------|------|---------|-------|
  | 230 | cold_tier_unavailable | Cannot access cold tier storage | Yes |
  | 231 | cold_tier_fetch_timeout | Cold tier fetch exceeded timeout | Yes |
  | 232 | migration_failed | Tier migration failed | No |
  | 233 | tier_storage_full | Target tier storage is full | No |

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Hot-Warm-Cold Tiering | ✓ Complete | `tiering.zig` |
| Automatic Tier Migration | ✓ Complete | Background migration |
| Migration Rate Limiting | ✓ Complete | Configurable throttle |
| Cold Tier Storage | ✓ Complete | S3-compatible backend |
| Tiering Metrics | ✓ Complete | Per-tier counters |
| Tiering Error Codes (230-233) | ✓ Complete | `error_codes.zig` |
