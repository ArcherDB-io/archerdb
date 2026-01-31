# Alert: ArcherDBDiskSpaceWarning / ArcherDBDiskSpaceCritical / ArcherDBDiskFillPrediction

## Quick Reference
- **Severity:**
  - Warning: > 80% full OR predicted to fill in 24h
  - Critical: > 90% full OR predicted to fill in 6h
- **Metrics:**
  - `archerdb_storage_free_bytes`
  - `archerdb_storage_total_bytes`
- **Threshold:** Warning: 80%, Critical: 90%, Predictive: 24h/6h fill time
- **Time to Respond:** Warning: 4 hours, Critical: 30 minutes

## What This Alert Means

Disk space is running low or trending toward exhaustion. If the disk fills completely:
- **Writes will fail** with out-of-space errors
- **Compaction will stall**, causing performance degradation
- **The database may become read-only** to protect data integrity

## Immediate Actions

1. [ ] Check current disk usage and free space
2. [ ] Identify largest consumers of space
3. [ ] Check if TTL cleanup is configured and running
4. [ ] Assess data growth rate

## Investigation

### Current Disk Status

```bash
# Check disk usage via metrics
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_storage

# Check disk usage on filesystem
kubectl exec archerdb-0 -n archerdb -- df -h /data

# Check data file size
kubectl exec archerdb-0 -n archerdb -- du -sh /data/archerdb.db
kubectl exec archerdb-0 -n archerdb -- ls -la /data/
```

### Growth Analysis

```bash
# Check entity count
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_entities_total

# Check write rate
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep 'archerdb_operations_total{.*insert'

# Check compaction status (compaction reclaims space)
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction
```

### Common Causes

- **High ingest rate:** Writing data faster than TTL can clean it
- **TTL not configured:** Data accumulating without automatic cleanup
- **Compaction behind:** Dead space not being reclaimed
- **Spillover files:** S3 backup failures causing local spillover
- **Logs/temp files:** Non-database files consuming space

## Resolution

### Immediate Space Relief

1. **Check for non-essential files:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- ls -la /data/
   # Look for spillover/, tmp/, or backup files
   ```

2. **Check spillover directory:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- du -sh /data/spillover/ 2>/dev/null
   # If large, check S3 backup status
   ```

3. **Force compaction (recovers dead space):**
   ```bash
   # This is automatic, but can be triggered manually
   kubectl exec archerdb-0 -n archerdb -- ./archerdb compact /data/archerdb.db
   ```

### Enable/Configure TTL Cleanup

1. **Check current TTL settings:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- ./archerdb info /data/archerdb.db | grep -i ttl
   ```

2. **Enable TTL via configuration:**
   ```yaml
   # values.yaml
   config:
     ttl_enabled: true
     ttl_default_hours: 168  # 7 days default
   ```

3. **TTL cleanup runs automatically** and removes expired events during queries and compaction.

### Expand Storage Capacity

**For Kubernetes PVC:**

1. **Check if StorageClass allows expansion:**
   ```bash
   kubectl get storageclass -o jsonpath='{.items[*].allowVolumeExpansion}'
   ```

2. **Expand PVC:**
   ```bash
   kubectl patch pvc data-archerdb-0 -n archerdb -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
   ```

3. **Note:** Pod restart may be required for some storage classes.

**For bare metal:**

1. Expand underlying storage (LVM, cloud disk, etc.)
2. Resize filesystem: `resize2fs /dev/sdX`

### Archive Old Data

If immediate deletion is not acceptable:

1. **Create backup of current data:**
   ```bash
   ./archerdb backup create --bucket=s3://archive-bucket --cluster-id=...
   ```

2. **Verify backup success:**
   ```bash
   ./archerdb backup list --bucket=s3://archive-bucket
   ```

3. **Consider time-based archival strategy** for compliance requirements.

## Prevention

### Monitoring

- **Alert at 70%:** Warning for early planning
- **Alert at 80%:** Urgent warning
- **Alert at 90%:** Critical
- **Predictive alerts:** Based on growth rate

### Capacity Planning

```bash
# Calculate growth rate
# Example: 10GB/day with 7-day TTL = 70GB steady state
# Add 50% headroom = 105GB minimum
```

| Daily Ingest | TTL (days) | Steady State | Recommended Size |
|-------------|------------|--------------|------------------|
| 1 GB        | 7          | 7 GB         | 15 GB           |
| 10 GB       | 7          | 70 GB        | 110 GB          |
| 10 GB       | 30         | 300 GB       | 450 GB          |
| 100 GB      | 7          | 700 GB       | 1 TB            |

### Retention Policies

1. **Set appropriate TTL** for your use case
2. **Use time-partitioned groups** for easier archival
3. **Implement data lifecycle** policies

## Emergency Procedures

### If Disk is 100% Full

1. **Database may be read-only.** Immediate action required.

2. **Free emergency space:**
   ```bash
   # Remove any non-essential files
   kubectl exec archerdb-0 -n archerdb -- rm -rf /data/tmp/* 2>/dev/null
   kubectl exec archerdb-0 -n archerdb -- rm -rf /data/spillover/* 2>/dev/null
   ```

3. **If database is read-only,** restart after freeing space:
   ```bash
   kubectl delete pod archerdb-0 -n archerdb
   ```

4. **Expand storage immediately** (see Expand Storage Capacity above).

### Emergency Data Deletion

**Warning:** This deletes data permanently.

```bash
# Delete all expired events immediately
./archerdb ttl-cleanup --force /data/archerdb.db

# Delete events older than specific time
./archerdb cleanup --older-than=2024-01-01 /data/archerdb.db
```

## Verification

After resolution:

```bash
# Verify disk usage decreased
kubectl exec archerdb-0 -n archerdb -- df -h /data

# Verify metrics updated
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_storage

# Monitor growth rate for next hour
watch -n 60 'kubectl exec archerdb-0 -n archerdb -- df -h /data'
```

## Related Documentation

- [Capacity Planning](../capacity-planning.md) - Sizing guidelines
- [Backup Operations](../backup-operations.md) - Backup procedures
- [Compaction Backlog](compaction-backlog.md) - If compaction is contributing to space issues
- [Operations Runbook](../operations-runbook.md) - General operations
