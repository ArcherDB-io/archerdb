# Observability v2 Spec Deltas

## ADDED Requirements

### Requirement: Multi-Region Replication Metrics

The system SHALL expose comprehensive metrics for cross-region replication monitoring.

#### Scenario: Replication lag metrics

- **WHEN** exposing replication metrics
- **THEN** the system SHALL provide:
  ```
  # Primary region (ships to followers)
  archerdb_replication_ship_queue_depth{follower="eu-west-1"} 150
  archerdb_replication_ship_queue_bytes{follower="eu-west-1"} 15728640
  archerdb_replication_ship_rate{follower="eu-west-1"} 10000
  archerdb_replication_ship_latency_seconds{follower="eu-west-1",quantile="0.99"} 0.15
  archerdb_replication_ship_failures_total{follower="eu-west-1",reason="timeout"} 5

  # Follower region (receives from primary)
  archerdb_replication_lag_ops{primary="us-west-2"} 500
  archerdb_replication_lag_seconds{primary="us-west-2"} 0.5
  archerdb_replication_apply_rate{primary="us-west-2"} 9500
  archerdb_replication_apply_errors_total{primary="us-west-2"} 0
  ```

#### Scenario: Region health metrics

- **WHEN** monitoring region health
- **THEN** the system SHALL provide:
  ```
  archerdb_region_role{region="us-west-2"} 1  # 1=primary, 0=follower
  archerdb_region_available{region="eu-west-1"} 1
  archerdb_region_last_heartbeat_seconds{region="eu-west-1"} 0.5
  ```

### Requirement: Sharding Metrics

The system SHALL expose metrics for shard health and distribution.

#### Scenario: Shard distribution metrics

- **WHEN** exposing shard metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_shard_entity_count{shard="0"} 250000000
  archerdb_shard_entity_count{shard="1"} 250000001
  archerdb_shard_size_bytes{shard="0"} 34359738368
  archerdb_shard_write_rate{shard="0"} 25000
  archerdb_shard_read_rate{shard="0"} 100000
  ```

#### Scenario: Shard balance metrics

- **WHEN** monitoring shard balance
- **THEN** the system SHALL provide:
  ```
  archerdb_shard_count 4
  archerdb_shard_balance_variance 0.02  # Standard deviation / mean
  archerdb_shard_hottest_ratio 1.05     # Hottest shard / average
  archerdb_shard_coldest_ratio 0.95     # Coldest shard / average
  ```
- **AND** variance >10% SHALL indicate rebalancing needed

#### Scenario: Resharding metrics

- **WHEN** resharding is in progress
- **THEN** the system SHALL provide:
  ```
  archerdb_resharding_status 1  # 0=idle, 1=planning, 2=migrating, 3=completing
  archerdb_resharding_progress 0.75
  archerdb_resharding_source_shards 4
  archerdb_resharding_target_shards 8
  archerdb_resharding_entities_migrated 375000000
  archerdb_resharding_entities_remaining 125000000
  archerdb_resharding_migration_rate 50000  # entities/sec
  ```

### Requirement: Encryption Metrics

The system SHALL expose metrics for encryption operations and key management.

#### Scenario: Encryption operation metrics

- **WHEN** exposing encryption metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_encryption_enabled 1
  archerdb_encryption_operations_total{op="encrypt"} 1000000
  archerdb_encryption_operations_total{op="decrypt"} 5000000
  archerdb_encryption_bytes_total{op="encrypt"} 128000000000
  archerdb_encryption_latency_seconds{op="encrypt",quantile="0.99"} 0.00001
  ```

#### Scenario: Key management metrics

- **WHEN** exposing key management metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_encryption_key_cache_hits_total 4999000
  archerdb_encryption_key_cache_misses_total 1000
  archerdb_encryption_key_rotations_total 5
  archerdb_encryption_key_age_seconds{key_type="kek"} 2592000
  archerdb_encryption_rotation_status 0  # 0=idle, 1=rotating
  ```

### Requirement: Tiering Metrics

The system SHALL expose metrics for data tiering and migration.

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

  archerdb_tier_access_rate{tier="hot"} 100000
  archerdb_tier_access_rate{tier="warm"} 10000
  archerdb_tier_access_rate{tier="cold"} 100
  ```

#### Scenario: Migration metrics

- **WHEN** exposing migration metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_tiering_migrations_total{direction="demotion",from="hot",to="warm"} 1000000
  archerdb_tiering_migrations_total{direction="promotion",from="cold",to="warm"} 50000

  archerdb_tiering_queue_depth{direction="demotion"} 5000
  archerdb_tiering_queue_depth{direction="promotion"} 100
  archerdb_tiering_migration_rate 950
  archerdb_tiering_migration_errors_total{reason="s3_timeout"} 10
  ```

#### Scenario: Cold tier performance metrics

- **WHEN** exposing cold tier metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_cold_tier_latency_seconds{quantile="0.5"} 0.5
  archerdb_cold_tier_latency_seconds{quantile="0.99"} 2.5
  archerdb_cold_tier_fetches_total 50000
  archerdb_cold_tier_fetch_bytes_total 6400000000
  ```

### Requirement: TTL Extension Metrics

The system SHALL expose metrics for TTL extension activity.

#### Scenario: TTL extension metrics

- **WHEN** exposing TTL extension metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_ttl_extensions_total 1000000
  archerdb_ttl_extensions_skipped_total{reason="cooldown"} 500000
  archerdb_ttl_extensions_skipped_total{reason="max_ttl"} 10000
  archerdb_ttl_extensions_skipped_total{reason="max_count"} 5000
  archerdb_ttl_extensions_skipped_total{reason="disabled"} 2000

  archerdb_ttl_extension_amount_seconds_sum 86400000000
  archerdb_ttl_extension_amount_seconds_count 1000000
  ```

### Requirement: v2 Health Endpoints

The system SHALL provide enhanced health endpoints for v2 features.

#### Scenario: Regional health endpoint

- **WHEN** checking regional health at `/health/region`
- **THEN** the system SHALL return:
  ```json
  {
    "region_id": "us-west-2",
    "role": "primary",
    "status": "healthy",
    "replication": {
      "followers": ["eu-west-1", "ap-southeast-1"],
      "ship_queue_depth": 150,
      "oldest_unshipped_op": 12345678
    }
  }
  ```

#### Scenario: Shard health endpoint

- **WHEN** checking shard health at `/health/shards`
- **THEN** the system SHALL return:
  ```json
  {
    "shard_count": 4,
    "shards": [
      {"id": 0, "status": "healthy", "leader": "node-1", "entity_count": 250000000},
      {"id": 1, "status": "healthy", "leader": "node-2", "entity_count": 250000001},
      {"id": 2, "status": "healthy", "leader": "node-3", "entity_count": 249999999},
      {"id": 3, "status": "healthy", "leader": "node-1", "entity_count": 250000000}
    ],
    "balance_variance": 0.02
  }
  ```

#### Scenario: Encryption health endpoint

- **WHEN** checking encryption health at `/health/encryption`
- **THEN** the system SHALL return:
  ```json
  {
    "encryption_enabled": true,
    "key_provider": "aws-kms",
    "kek_status": "valid",
    "kek_rotation_due": false,
    "encrypted_files": 1234,
    "unencrypted_files": 0,
    "rotation_in_progress": false
  }
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Multi-Region Replication Metrics | ✓ Complete | Lag, byte counters |
| Sharding Metrics | ✓ Complete | Per-shard stats |
| Encryption Metrics | ✓ Complete | Op counters, cache stats |
| Tiering Metrics | ✓ Complete | Migration, access patterns |
| TTL Extension Metrics | ✓ Complete | Counter placeholders |
| v2 Health Endpoints | ✓ Complete | /health/shards, /health/encryption |
