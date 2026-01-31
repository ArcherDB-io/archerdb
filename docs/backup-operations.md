# Backup Operations Guide

This document provides comprehensive guidance for configuring, monitoring, and troubleshooting ArcherDB backups.

## Table of Contents

- [Overview](#overview)
- [Configuration](#configuration)
- [Retention Policies](#retention-policies)
- [Operations](#operations)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## Overview

### Backup Architecture

ArcherDB uses a CDC-style (Change Data Capture) continuous backup system that uploads closed LSM blocks to object storage. This architecture provides:

- **Near-zero RPO**: Blocks are backed up as soon as they're closed
- **Minimal overhead**: Asynchronous upload doesn't block write path
- **Incremental by design**: Only new blocks are uploaded

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Client    │───>│  ArcherDB   │───>│   Object    │
│   Writes    │    │   Replica   │    │   Storage   │
└─────────────┘    └──────┬──────┘    └─────────────┘
                         │
                   LSM Block Closes
                         │
                         v
                  ┌──────────────┐
                  │    Backup    │
                  │ Coordinator  │
                  └──────┬───────┘
                         │
                  Upload to S3/GCS/Azure
```

### Zero-Impact Design (Follower-Only Mode)

By default, ArcherDB runs backups only on follower replicas (`follower_only = true`). This ensures:

- **No primary impact**: Backup I/O doesn't compete with client traffic
- **Consistent performance**: P99 latency unaffected during backups
- **Automatic failover**: If a follower becomes primary, backup pauses

```
3-Node Cluster with follower_only=true:

  ┌─────────┐     ┌─────────┐     ┌─────────┐
  │ Primary │     │Follower1│     │Follower2│
  │  (R0)   │     │  (R1)   │     │  (R2)   │
  └────┬────┘     └────┬────┘     └────┬────┘
       │               │               │
   No backup      Backup active   Backup active
       │               │               │
                  ┌────┴────┐     ┌────┴────┐
                  │  Upload │     │  Upload │
                  │  to S3  │     │  to S3  │
                  └─────────┘     └─────────┘
```

### Incremental Backup Strategy

ArcherDB tracks the last backed up sequence number and only uploads blocks with sequences higher than this value:

1. **Sequence tracking**: Each block has a monotonically increasing sequence number
2. **State persistence**: Last backed up sequence is persisted to disk
3. **Crash recovery**: On restart, backup resumes from last known good sequence
4. **Deduplication**: Blocks already in object storage are never re-uploaded

## Configuration

### Enabling Backup

Enable backup via configuration file (`archerdb.conf`):

```ini
# Enable backup
backup.enabled = true

# Storage provider: s3, gcs, azure, or local
backup.provider = s3

# Bucket name (provider-specific format)
backup.bucket = archerdb-backups
backup.region = us-east-1

# Follower-only mode (default: true, recommended)
backup.follower_only = true
```

Or via environment variables:

```bash
export ARCHERDB_BACKUP_ENABLED=true
export ARCHERDB_BACKUP_PROVIDER=s3
export ARCHERDB_BACKUP_BUCKET=archerdb-backups
export ARCHERDB_BACKUP_REGION=us-east-1
export ARCHERDB_BACKUP_FOLLOWER_ONLY=true
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `backup.enabled` | `false` | Enable/disable backup |
| `backup.provider` | `s3` | Storage provider: `s3`, `gcs`, `azure`, `local` |
| `backup.bucket` | - | Bucket or container name |
| `backup.region` | - | Cloud region (provider-specific) |
| `backup.follower_only` | `true` | Only backup on follower replicas |
| `backup.primary_only` | `false` | Only backup on primary (mutually exclusive with follower_only) |
| `backup.mode` | `best-effort` | Backup mode: `best-effort` or `mandatory` |
| `backup.schedule` | - | Schedule: cron (`0 2 * * *`) or interval (`every 1h`) |
| `backup.encryption` | `sse` | Encryption: `none`, `sse`, `sse-kms` |
| `backup.kms_key_id` | - | KMS key ID (required for `sse-kms`) |
| `backup.compression` | `none` | Compression: `none` or `zstd` |
| `backup.queue_soft_limit` | `50` | Log warning when queue exceeds this |
| `backup.queue_hard_limit` | `100` | Apply backpressure at this limit |
| `backup.credentials_path` | - | Path to credentials file |

### Backup Modes

#### Best-Effort Mode (Default)

In best-effort mode, backups are asynchronous and non-blocking:

```ini
backup.mode = best-effort
```

- Writes continue even if backup is slow
- Queue overflow results in blocks being skipped (logged as warnings)
- Suitable for most workloads

#### Mandatory Mode

In mandatory mode, writes halt if backup falls behind:

```ini
backup.mode = mandatory
backup.mandatory_halt_timeout_secs = 3600  # 1 hour timeout
```

- Guarantees every block is backed up
- Writes pause if queue is full
- Emergency bypass after timeout
- Required for regulated environments

### Scheduling

Configure backup schedule using cron expressions or simple intervals:

```ini
# Cron format: minute hour day-of-month month day-of-week
backup.schedule = 0 2 * * *      # Daily at 2am

# Interval format
backup.schedule = every 1h       # Every hour
backup.schedule = every 30m      # Every 30 minutes
backup.schedule = every 1d       # Daily
```

### Coordination Modes

#### Follower-Only (Recommended)

```ini
backup.follower_only = true
backup.primary_only = false
```

- Backups run only on follower replicas
- Zero impact on client-facing traffic
- Automatic pause when follower becomes primary

#### Primary-Only

```ini
backup.follower_only = false
backup.primary_only = true
```

- Only primary backs up (reduces storage costs)
- Backup path changes on view change
- Lower redundancy

#### All Replicas

```ini
backup.follower_only = false
backup.primary_only = false
```

- Every replica backs up independently
- Maximum redundancy
- Higher storage costs (N copies)

## Retention Policies

### Default Retention

The default retention policy provides comprehensive coverage:

- **7 daily** backups
- **4 weekly** backups (retained from weekly snapshots)
- **12 monthly** backups (retained from monthly snapshots)

### Configuring Retention

```ini
# Retention by days
backup.retention_days = 30

# Retention by block count
backup.retention_blocks = 1000
```

### Retention Considerations

| Policy | Storage Cost | Recovery Window | Use Case |
|--------|--------------|-----------------|----------|
| 7d retention | Low | 1 week | Development |
| 30d retention | Medium | 1 month | Standard production |
| 90d retention | High | 3 months | Compliance requirements |
| 365d retention | Very high | 1 year | Long-term audit |

## Operations

### Starting Backup

Backup starts automatically based on configuration:

1. **On startup**: If `backup.enabled = true`
2. **On schedule**: If `backup.schedule` is configured
3. **Continuous**: Blocks are queued as they close

### Verifying Backup Status

Check backup status via metrics endpoint:

```bash
# Check last successful backup timestamp
curl -s localhost:9090/metrics | grep archerdb_backup_last_success

# Check backup queue depth
curl -s localhost:9090/metrics | grep archerdb_backup_blocks_queued

# Check blocks uploaded
curl -s localhost:9090/metrics | grep archerdb_backup_blocks_uploaded
```

### Listing Backups

Use provider-specific tools to list backups:

```bash
# AWS S3
aws s3 ls s3://archerdb-backups/<cluster-id>/

# Google Cloud Storage
gsutil ls gs://archerdb-backups/<cluster-id>/

# Azure Blob Storage
az storage blob list --container-name archerdb-backups --prefix <cluster-id>/

# Local filesystem
ls /var/lib/archerdb/backups/<cluster-id>/
```

### Backup Verification

Verify backup integrity periodically:

```bash
./archerdb backup verify \
  --bucket=s3://archerdb-backups \
  --cluster-id=<cluster-id>
```

This validates:
- Block checksums match
- Sequence continuity
- All expected blocks present

## Monitoring

### Prometheus Metrics

ArcherDB exports the following backup-related metrics:

| Metric | Type | Description |
|--------|------|-------------|
| `archerdb_backup_blocks_queued` | Gauge | Blocks waiting for upload |
| `archerdb_backup_blocks_uploaded` | Counter | Total blocks uploaded |
| `archerdb_backup_last_success_timestamp` | Gauge | Unix timestamp of last successful backup |
| `archerdb_backup_role_skipped_total` | Counter | Backups skipped due to role (follower_only mode) |
| `archerdb_backup_upload_duration_seconds` | Histogram | Upload latency distribution |
| `archerdb_backup_upload_errors_total` | Counter | Upload failures |
| `archerdb_backup_sequence_lag` | Gauge | Difference between latest and backed up sequence |

### Alerting

Recommended alert rules:

```yaml
groups:
  - name: archerdb_backup
    rules:
      # Alert if no backup in 4 hours
      - alert: BackupStale
        expr: time() - archerdb_backup_last_success_timestamp > 14400
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ArcherDB backup is stale"

      # Alert if backup queue is growing
      - alert: BackupQueueHigh
        expr: archerdb_backup_blocks_queued > 50
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "ArcherDB backup queue is high"

      # Alert if backup is failing
      - alert: BackupFailing
        expr: increase(archerdb_backup_upload_errors_total[1h]) > 10
        labels:
          severity: critical
        annotations:
          summary: "ArcherDB backup uploads are failing"
```

### Log Messages

Key backup log messages to monitor:

```
INFO  Backup coordinator initialized as follower (view=0, replica=1) - zero-impact mode
INFO  Backup started: 150 blocks queued
INFO  Backup progress: 50/150 blocks uploaded
INFO  Backup completed: 150 blocks in 45s
WARN  Backup queue soft limit reached (50 blocks)
ERROR Backup upload failed: S3 permission denied
```

## Troubleshooting

### Backup Not Running on Primary

**Symptom**: Backup metrics show no activity on primary replica.

**Cause**: This is expected behavior with `follower_only = true` (default).

**Solution**: If you need primary-only backup, configure:
```ini
backup.follower_only = false
backup.primary_only = true
```

### Queue Exhaustion in Mandatory Mode

**Symptom**: Writes are halting, logs show "backup queue exhausted".

**Cause**: Backup uploads can't keep up with write rate.

**Solutions**:
1. Increase queue limits:
   ```ini
   backup.queue_soft_limit = 100
   backup.queue_hard_limit = 200
   ```
2. Check network connectivity to object storage
3. Verify storage provider credentials
4. Consider switching to `best-effort` mode temporarily

### S3 Permission Errors

**Symptom**: Logs show "Access Denied" or "403 Forbidden".

**Cause**: IAM role or credentials lack required permissions.

**Solution**: Ensure IAM policy includes:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::archerdb-backups",
        "arn:aws:s3:::archerdb-backups/*"
      ]
    }
  ]
}
```

### Network Timeout Handling

**Symptom**: Backup uploads timing out intermittently.

**Cause**: Network latency or object storage throttling.

**Solutions**:
1. Check network path to object storage
2. Verify no firewall blocking outbound connections
3. Consider using a regional bucket closer to your cluster
4. Enable retry with exponential backoff (default behavior)

### Single-Replica Cluster with follower_only

**Symptom**: Backup never runs on single-replica deployment.

**Cause**: Single replica is always primary, so `follower_only = true` skips backup.

**Solution**: For single-replica deployments, disable follower_only:
```ini
backup.follower_only = false
```

### Backup Sequence Gap

**Symptom**: Backup verification shows missing sequence numbers.

**Cause**: Blocks were released before backup in `best-effort` mode.

**Solutions**:
1. Use `mandatory` mode for gap-free backups
2. Increase queue limits to avoid overflow
3. Monitor `archerdb_backup_blocks_abandoned` metric

## Best Practices

### Production Recommendations

1. **Enable follower_only mode** (default) for zero-impact backups
2. **Use mandatory mode** for regulated workloads requiring complete backup
3. **Monitor backup lag** with alerting on `archerdb_backup_sequence_lag`
4. **Test restore procedures** monthly (see [Disaster Recovery](disaster-recovery.md))
5. **Enable bucket versioning** for protection against accidental deletion
6. **Configure cross-region replication** for disaster recovery

### Capacity Planning

Estimate backup storage requirements:

```
Daily storage = (write_rate_MB_per_sec * 86400) / compression_ratio
Monthly storage = Daily storage * 30 * retention_factor
```

Example for 10 MB/s write rate with zstd compression (2:1) and 30-day retention:
```
Daily = (10 * 86400) / 2 = 432 GB
Monthly = 432 * 30 * 1.2 = 15.5 TB (with retention overlap)
```

### Security Recommendations

1. **Enable encryption**: Use `sse-kms` for customer-managed keys
2. **Restrict bucket access**: Use IAM policies to limit access
3. **Enable access logging**: Track who accesses backup data
4. **Use VPC endpoints**: Avoid public internet for backup traffic
5. **Rotate credentials**: If using static credentials, rotate regularly

## Related Documentation

- [Disaster Recovery Procedures](disaster-recovery.md) - Restore and recovery procedures
- [Capacity Planning](capacity-planning.md) - Storage sizing guidelines
- [Operations Runbook](operations-runbook.md) - Operational procedures
- [Troubleshooting Guide](troubleshooting.md) - General troubleshooting

---
*Last updated: 2026-01-31*
