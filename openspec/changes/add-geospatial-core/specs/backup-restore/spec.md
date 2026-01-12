# Backup and Restore Specification

## ADDED Requirements

### Requirement: Object Storage Backup

The system SHALL support backing up closed log blocks to object storage (S3, GCS, Azure Blob) for disaster recovery.

#### Scenario: Backup trigger

- **WHEN** an LSM grid block is written and becomes immutable
- **THEN** a background thread SHALL:
  1. Verify block checksum integrity
  2. Upload block to configured object storage bucket
  3. Verify upload succeeded
  4. Log backup completion with block address and sequence number
- **AND** "closed block" means an LSM grid block that has been written to disk and is no longer mutable
- **AND** blocks are uploaded as-is (no event-level filtering in v1)
- **AND** this includes tombstones (`flags.deleted = true`) which are required to prevent data resurrection on restore

#### Scenario: Backup configuration

- **WHEN** configuring backup
- **THEN** the following SHALL be supported:
  ```
  archerdb start \
    --backup-enabled=true \
    --backup-provider=s3 \
    --backup-bucket=s3://archerdb-backups \
    --backup-region=us-east-1 \
    --backup-credentials=~/.aws/credentials
  ```

#### Scenario: Backup encryption

- **WHEN** uploading blocks to object storage
- **THEN** the system SHALL:
  - Enable Server-Side Encryption (SSE) by default (e.g., SSE-S3 or SSE-KMS)
  - Support configuring KMS key IDs via `--backup-kms-key-id`
  - Ensure data is encrypted in transit using TLS
- **AND** this ensures compliance with GDPR and security best practices for data in the cloud.

#### Scenario: Backup mandatory mode halt timeout

- **WHEN** `backup-mode=mandatory` is enabled
- **AND** writes are halted due to backup queue exhaustion
- **AND** the halt persists for > `--backup-mandatory-halt-timeout` (default: 1 hour)
- **THEN** the system SHALL:
  1. Transition to "emergency-bypass" state
  2. Automatically switch to `best-effort` mode
  3. Log CRITICAL alert: "Backup mandatory mode HALT TIMEOUT exceeded - switching to best-effort to restore availability"
  4. Resume writes
  5. Increment metric: `archerdb_backup_mandatory_bypass_total`
- **AND** this prevents permanent cluster freezes if S3 is indefinitely unreachable.

#### Scenario: Backup file naming convention

- **WHEN** uploading blocks to object storage
- **THEN** files SHALL be named:
  ```
  s3://<bucket>/<cluster-id>/<replica-id>/blocks/<sequence>.block

  Example:
  s3://archerdb-backups/abc123.../replica-0/blocks/00001000.block
  s3://archerdb-backups/abc123.../replica-0/blocks/00001001.block
  ```
- **AND** sequence numbers are zero-padded for sorting

#### Scenario: Backup metadata

- **WHEN** uploading a block
- **THEN** object metadata SHALL include:
  - `x-archerdb-cluster-id`: Cluster UUID
  - `x-archerdb-replica-id`: Replica ID (0-5)
  - `x-archerdb-sequence`: Block sequence number
  - `x-archerdb-checksum`: Block checksum (hex)
  - `x-archerdb-min-id`: Minimum GeoEvent ID in block
  - `x-archerdb-max-id`: Maximum GeoEvent ID in block
  - `x-archerdb-count`: Number of events in block

### Requirement: Backup and Compaction Interaction

The system SHALL coordinate backup and LSM compaction to prevent data loss.

#### Scenario: Block lifecycle protection during backup

- **WHEN** a grid block is pending backup upload
- **THEN** it SHALL remain in Free Set "acquired" state
- **AND** Free Set SHALL track backup-pending blocks separately (via additional state or bitset)
- **AND** LSM compaction SHALL check Free Set before releasing blocks
- **AND** blocks transition to "released" state only after successful backup upload
- **AND** this prevents compaction from reclaiming blocks before they're safely backed up

#### Scenario: Backup queue and Free Set coordination

- **WHEN** a block is queued for backup
- **THEN** Free Set SHALL:
  1. Keep block in "acquired" state (not available for reuse)
  2. Track block in backup_pending set (implementation-specific)
  3. After upload completes successfully, transition to "released" state
  4. Released blocks become eligible for reuse after next checkpoint
- **AND** this coordination is CRITICAL for preventing data loss

#### Scenario: Backup queue integration

- **WHEN** LSM compaction wants to free a block
- **THEN** it SHALL check if block is in backup queue
- **AND** if pending backup: delay free until upload completes
- **AND** if backup fails permanently: log error and allow free (data loss acknowledged)

### Requirement: Backup Operating Modes

The system SHALL support two distinct backup operating modes with different durability guarantees.

#### Scenario: Best-effort backup mode (default)

- **WHEN** `--backup-mode=best-effort` (or no mode specified)
- **THEN** the system SHALL:
  - Perform backups asynchronously in background
  - Prioritize database availability over backup completeness
  - Allow blocks to be released without backup completion if:
    - Free Set is exhausted AND backup queue is backed up
    - Backup queue hard limit exceeded
  - Log warnings when blocks are released without backup
  - Continue operating even if S3 is unreachable
- **AND** this mode is appropriate for:
  - Development and testing environments
  - Non-critical data where local replicas provide sufficient durability
  - High-throughput scenarios where backup lag is acceptable

#### Scenario: Backup-mandatory mode (opt-in)

- **WHEN** `--backup-mode=mandatory` is configured
- **THEN** the system SHALL:
  - Require ALL blocks to be successfully backed up before release
  - Apply write backpressure if backup queue exceeds `backup_queue_soft_limit` (50 blocks)
  - HALT writes entirely if backup queue exceeds `backup_queue_capacity` (100 blocks in mandatory mode)
  - NEVER release blocks without confirmed backup upload (unless emergency bypass timeout is exceeded)
  - Resume writes only after backup queue drains below soft limit
- **AND** when writes are halted:
  - Return `backup_required` error (code 207) to clients
  - Log critical alert: "Writes halted - backup mandatory mode, queue full"
  - Continue serving reads from existing data
  - Resume automatically when backup queue drains
- **AND** this mode is appropriate for:
  - Financial and compliance-sensitive data
  - Healthcare (HIPAA) and regulated industries
  - Scenarios where S3 durability is required before acknowledging writes

#### Scenario: Backup mode configuration

- **WHEN** configuring backup mode
- **THEN** the following SHALL be supported:
  ```
  archerdb start \
    --backup-enabled=true \
    --backup-mode=mandatory \           # or 'best-effort' (default)
    --backup-queue-soft-limit=50 \      # Warning threshold
    --backup-queue-hard-limit=100 \     # Hard limit (halt in mandatory mode)
    --backup-provider=s3 \
    --backup-bucket=s3://archerdb-backups
  ```

#### Scenario: Mode-specific error codes

- **WHEN** backup-mandatory mode blocks writes
- **THEN** clients SHALL receive:
  - `backup_required = 207` - Writes halted pending backup
  - Error message includes: queue depth, estimated drain time
  - `Retry-After` header with estimated resume time

#### Scenario: Mode switching at runtime

- **WHEN** operator changes backup mode at runtime
- **THEN** the system SHALL:
  - Allow switching from mandatory → best-effort immediately
  - When switching best-effort → mandatory:
    - First drain existing backup queue below soft limit
    - Then enable mandatory semantics
    - Log: "Backup mode changed to mandatory"
- **AND** mode changes are NOT persisted across restarts (must be set via CLI flags on restart)

### Requirement: Asynchronous Backup

The system SHALL perform backups asynchronously without blocking database operations (in best-effort mode).

#### Scenario: Background upload thread

- **WHEN** backup is enabled
- **THEN** a dedicated background thread SHALL:
  - Monitor for newly closed blocks
  - Upload to object storage using async I/O
  - Retry failed uploads with exponential backoff
  - Not block writes or compaction

#### Scenario: Backup queue depth

- **WHEN** backups fall behind (network slow)
- **THEN** the system SHALL:
  - Queue up to 100 pending blocks for upload
  - Log warning if queue depth exceeds 50
  - Continue database operations (backup is async)
  - Catch up when network recovers

#### Scenario: Backup failure handling

- **WHEN** backup upload fails
- **THEN** the system SHALL:
  - Retry with exponential backoff (1s, 2s, 4s, 8s, 16s max)
  - Log error after 5 failed attempts
  - Continue attempting in background
  - Database continues operating (backup failure is not fatal)

#### Scenario: Backup queue overflow prevention (deadlock avoidance)

- **WHEN** backup queue reaches `backup_queue_capacity` (100 pending blocks)
- **AND** a new block needs to be queued for backup
- **THEN** the system SHALL:
  1. Log critical alert: "Backup queue full - blocks at risk"
  2. Continue accepting the new block (queue becomes 101)
  3. If queue exceeds `backup_queue_hard_limit` (default: 200):
     - **OPTION A (default, data preservation):** Apply backpressure - slow checkpoint frequency
     - **OPTION B (configurable):** Allow oldest pending block to be released WITHOUT backup
  4. Log which option was taken with affected block addresses
- **AND** operator MUST investigate network/S3 issues immediately

#### Scenario: Free Set exhaustion during backup backlog

- **WHEN** Free Set runs low on blocks (< 10% capacity)
- **AND** backup queue has > `backup_queue_soft_limit` pending blocks
- **THEN** the system SHALL:
  1. Calculate: can checkpoint complete with current free blocks?
  2. If YES: proceed normally, backup will catch up
  3. If NO: enter "backup emergency mode":
     - Log critical alert: "Disk space pressure with backup backlog"
     - Release oldest backup-pending blocks WITHOUT backup completion
     - Increment metric: `archerdb_backup_blocks_abandoned_total`
     - Continue operating (data loss in backup, but primary remains intact)
- **AND** this prevents checkpoint deadlock at cost of backup completeness
- **AND** abandoned blocks are still on local disk (just not backed up to S3)

#### Scenario: Backup backlog recovery

- **WHEN** backup backlog clears (queue < 10 blocks)
- **THEN** the system SHALL:
  - Log info: "Backup backlog cleared"
  - Resume normal backup queue limits
  - Report backup gap if any blocks were abandoned
  - Operator may need to trigger full backup if gap is large

### Requirement: Point-in-Time Restore

The system SHALL support restoring data from object storage backups to a specific point in time.

#### Scenario: Restore command

- **WHEN** restoring from backup
- **THEN** the following command SHALL be supported:
  ```
  archerdb restore \
    --from-s3=s3://archerdb-backups/<cluster-id>/<replica-id> \
    --to-data-file=/path/to/data.archerdb \
    --point-in-time=<timestamp-or-sequence> \
    --skip-expired  # Optional: filter out expired events during restore
  ```

#### Scenario: Restore process

- **WHEN** restore executes
- **THEN** the process SHALL:
  1. List all blocks in S3 bucket (sorted by sequence)
  2. Download blocks up to specified point-in-time
  3. Verify each block checksum
  4. Write blocks to local data file
  5. Optionally filter expired events (if --skip-expired)
     - Tombstones (`flags.deleted = true`) MUST NOT be filtered (they prevent resurrection)
  6. Build RAM index from restored blocks
     - If `flags.deleted = true`: delete entity from index
     - Else: upsert entity in index (LWW)
  7. Write superblock with restore metadata

#### Scenario: Restore with TTL filtering

- **WHEN** `--skip-expired` flag is used
- **THEN** the system SHALL:
  - Check each GeoEvent's TTL during restore
  - Skip expired events (don't write to data file)
  - Reduce data file size (only active data)
  - Faster index rebuild (fewer entries)

#### Scenario: Restore verification

- **WHEN** restore completes
- **THEN** the system SHALL:
  - Verify all downloaded blocks have valid checksums
  - Verify index was built successfully
  - Log statistics: blocks restored, events restored, events skipped (if TTL filtering)
  - Exit with success code if verification passes

### Requirement: Incremental Backup

The system SHALL support incremental backups by only uploading new blocks since last backup.

#### Scenario: Backup state tracking

- **WHEN** backup is running
- **THEN** the system SHALL track:
  ```zig
  BackupState {
      last_uploaded_sequence: u64,  // Highest block sequence uploaded
      pending_uploads: BoundedArray(BlockRef, 100),
      failed_uploads: BoundedArray(BlockRef, 100),
  }
  ```
- **AND** state is persisted to local file periodically

#### Scenario: Resume after restart

- **WHEN** replica restarts with backup enabled
- **THEN** the system SHALL:
  1. Load backup state from disk
  2. Identify blocks newer than last_uploaded_sequence
  3. Queue those blocks for upload
  4. Resume background uploads

### Requirement: Backup Retention Policy

The system SHALL support configurable retention policies for backups in object storage.

#### Scenario: Retention configuration

- **WHEN** configuring backup retention
- **THEN** the following SHALL be supported:
  ```
  --backup-retention-days=90  # Keep backups for 90 days
  --backup-retention-blocks=10000  # OR keep last 10K blocks
  ```

#### Scenario: GDPR erasure guidance for backups

- **WHEN** ArcherDB is used to store personal location data
- **AND** operators must support "right to erasure" requests
- **THEN** operators SHALL ensure that `backup-retention-days` DOES NOT exceed the organization's GDPR erasure window (typically 30 days)
- **AND** this ensures that deleted data is physically removed from immutable object storage within the legal timeframe
- **AND** v1 does not rewrite historical backup blocks; erasure is achieved exclusively via object expiration policy
- **AND** operators SHALL configure `--backup-retention-days=30` (or less) for production clusters handling personal data

#### Scenario: Retention enforcement

- **WHEN** retention policy is configured
- **THEN** the background thread SHALL:
  - Periodically (every 24 hours) list old blocks in S3
  - Delete blocks older than retention period
  - Keep at least the most recent complete checkpoint
  - Log deletions for audit trail

### Requirement: Multi-Replica Backup Coordination

The system SHALL handle backups from multiple replicas without duplication.

#### Scenario: Per-replica backup paths

- **WHEN** multiple replicas backup to same bucket
- **THEN** each SHALL use separate paths:
  ```
  s3://<bucket>/<cluster-id>/replica-0/blocks/...
  s3://<bucket>/<cluster-id>/replica-1/blocks/...
  s3://<bucket>/<cluster-id>/replica-2/blocks/...
  ```
- **AND** replicas do not interfere with each other

#### Scenario: Backup from primary only (optional)

- **WHEN** configured for primary-only backup
- **THEN** only the current primary uploads blocks
- **AND** this reduces S3 costs (no redundant uploads)
- **AND** on view change, new primary resumes backup
- **BUT** this is optional; default is all replicas backup (safer)

### Requirement: Restore from Any Replica

The system SHALL support restoring from any replica's backup, preferring the most complete.

#### Scenario: Multi-replica restore selection

- **WHEN** multiple replica backups exist
- **THEN** restore SHALL:
  1. List blocks from all replicas
  2. Select replica with highest sequence number
  3. Download from that replica
  4. Fall back to other replicas if blocks missing

### Requirement: Backup Compression (Optional)

The system SHALL support compressing blocks before upload to reduce storage costs.

#### Scenario: Compression option

- **WHEN** configured with `--backup-compress=zstd`
- **THEN** blocks SHALL be compressed before upload
- **AND** compression SHALL use zstd level 3 (balance speed/ratio)
- **AND** file extension SHALL be `.block.zst`
- **AND** restore SHALL detect and decompress automatically

#### Scenario: Compression trade-off

- **WHEN** evaluating compression
- **THEN** consider:
  - GeoEvent structs compress ~1.5-2x (fields have patterns)
  - Compression CPU cost vs network cost
  - S3 storage cost reduction
- **AND** compression is optional (default: disabled for simplicity)

### Requirement: Backup Monitoring

The system SHALL expose metrics for backup health monitoring.

#### Scenario: Backup metrics

- **WHEN** exposing backup metrics
- **THEN** the following SHALL be included:
  ```
  # Total blocks uploaded
  archerdb_backup_blocks_uploaded_total counter

  # Backup lag (blocks not yet uploaded)
  archerdb_backup_lag_blocks gauge

  # Backup failures
  archerdb_backup_failures_total counter

  # Last successful backup timestamp
  archerdb_backup_last_success_timestamp gauge

  # Backup upload latency
  archerdb_backup_upload_latency_seconds histogram

  # Current Recovery Point Objective (seconds since oldest un-backed-up block was written)
  # In mandatory mode: should stay below RPO target
  # In best-effort mode: may grow unbounded if S3 unreachable
  archerdb_backup_rpo_current_seconds gauge

  # Blocks abandoned without backup (best-effort mode, Free Set pressure)
  archerdb_backup_blocks_abandoned_total counter
  ```

### Requirement: Restore Validation

The system SHALL validate restored data for integrity.

#### Scenario: Post-restore checks

- **WHEN** restore completes
- **THEN** the system SHALL verify:
  - All block checksums valid
  - No gaps in sequence numbers (within requested range)
  - Index rebuilt successfully
  - Superblock written correctly
- **AND** if any check fails, restore SHALL abort with error

#### Scenario: Restore dry-run

- **WHEN** restore is called with `--dry-run` flag
- **THEN** the system SHALL:
  - Download and verify blocks
  - Calculate statistics (events, disk usage)
  - NOT write to data file
  - Print report and exit

### Requirement: Disaster Recovery SLA

The system SHALL define recovery time objectives for disaster recovery scenarios.

#### Scenario: Recovery time objective

- **GIVEN** complete data center loss
- **WHEN** restoring from S3 backup
- **THEN** recovery time SHALL be:
  - Download time: `(data_size / network_bandwidth)`
  - Index rebuild: `(entity_count / index_insertion_rate)` + disk read time
  - Example for 1TB data (1B entities) on 10Gbps network + 3GB/s NVMe:
    - Download: ~14 minutes
    - Disk read: ~6 minutes
    - Index rebuild (1B entities): ~40-60 minutes (see ttl-retention/spec.md for targets)
    - **Total RTO: 60-90 minutes for 1B entities**
  - NOTE: Index rebuild is the bottleneck, not data transfer

#### Scenario: Recovery point objective

- **GIVEN** continuous backup enabled
- **WHEN** disaster occurs
- **THEN** maximum data loss SHALL be:
  - Time for LSM to flush in-memory table + upload block
  - Typical: <60 seconds for moderate write rates
  - Under sustained high load (1M events/sec): may increase to 2-5 minutes
  - **RPO: <1 minute typical, <5 minutes under sustained peak load**

### Related Specifications

- See `specs/storage-engine/spec.md` for checkpoint format and superblock structure
- See `specs/replication/spec.md` for VSR checkpoint coordination
- See `specs/ttl-retention/spec.md` for TTL filtering during restore
- See `specs/hybrid-memory/spec.md` for index rebuild after restore
- See `specs/observability/spec.md` for backup monitoring metrics



## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Full Backup | ✓ Complete | \`backup_coordinator.zig\` |
| Incremental Backup | ✓ Complete | Checkpoint-based |
| S3 Integration | ✓ Complete | \`backup_queue.zig\` |
| Restore from Backup | ✓ Complete | \`restore.zig\` |
| Backup Scheduling | ✓ Complete | Configurable intervals |
| Backup Validation | ✓ Complete | Checksum verification |
| Index Rebuild on Restore | ✓ Complete | LSM-aware rebuild |
| Backup Metrics | ✓ Complete | Progress tracking |
