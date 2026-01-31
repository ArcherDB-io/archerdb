# Alert: ArcherDBWriteLatencyP99Warning / ArcherDBWriteLatencyP99Critical / ArcherDBHighLatency

## Quick Reference
- **Severity:** warning (P99 > 25ms), critical (P99 > 100ms)
- **Metric:** `archerdb_write_latency_seconds` / `archerdb_request_duration_seconds`
- **Threshold:** Warning: 25ms, Critical: 100ms
- **Time to Respond:** Warning: 1 hour, Critical: 15 minutes

## What This Alert Means

Write operations are taking longer than acceptable thresholds. This typically indicates:
- **Compaction backlog:** LSM tree compaction falling behind write rate
- **WAL pressure:** Write-ahead log synchronization delays
- **Consensus delays:** Replication latency affecting commits

## Immediate Actions

1. [ ] Check compaction backlog size
2. [ ] Verify disk I/O is not saturated
3. [ ] Check WAL directory usage
4. [ ] Review replication lag on followers

## Investigation

### Common Causes

- **Compaction backlog:** Too many L0 files waiting for compaction
- **Disk saturation:** Write bandwidth exhausted
- **WAL sync delays:** Slow fsync operations
- **Consensus timeout:** Network issues causing replication delays
- **Large batch sizes:** Individual batches too large

### Diagnostic Commands

```bash
# Check current write latency
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_write_latency_seconds

# Check compaction backlog
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_pending_bytes
# > 1GB indicates significant backlog

# Check L0 file count
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_lsm_level_0_files
# > 8 files indicates compaction is behind

# Check disk I/O
kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
# await > 10ms or %util > 80% indicates saturation

# Check WAL metrics
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_wal

# Check replication lag
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_replication_lag
```

### Log Analysis

```bash
# Check for compaction stalls
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "compaction"

# Check for WAL warnings
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "wal"

# Check for consensus delays
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "commit\|consensus"
```

## Resolution

### Compaction Backlog

1. **Check backlog size:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_pending_bytes
   ```

2. **If > 1GB, tune compaction settings:**
   ```yaml
   # values.yaml - Phase 5 optimized defaults
   config:
     lsm_l0_compaction_trigger: 8  # Allow more L0 files before compaction
     lsm_compaction_threads: 3     # More parallel compaction
   ```

3. **For immediate relief, reduce write rate temporarily:**
   - Increase batch submission interval
   - Defer non-critical writes

4. **See [Compaction Backlog Runbook](compaction-backlog.md) for detailed guidance.**

### Disk Saturation

1. **Check disk metrics:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
   ```

2. **If saturated:**
   - Upgrade to faster storage (NVMe)
   - Reduce write rate
   - Consider sharding to distribute writes

### Large Batch Sizes

1. **Check batch size metrics:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_batch_size
   ```

2. **If batches > 5000 events:**
   - Reduce batch size to 1000-2000 for lower latency
   - Trade-off: smaller batches = lower throughput but more consistent latency

### Consensus Delays

1. **Check replication lag:**
   ```bash
   for i in 0 1 2; do
     echo -n "archerdb-$i lag: "
     kubectl exec archerdb-$i -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_replication_lag
   done
   ```

2. **If lag > 100ms, investigate network:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- ping -c 10 archerdb-1.archerdb-headless.archerdb.svc.cluster.local
   ```

3. **See [View Changes Runbook](view-changes.md) if consensus is unstable.**

## Tuning Write Performance

### Batch Size Optimization

| Batch Size | Throughput | Latency | Use Case |
|------------|------------|---------|----------|
| 100-500    | Lower      | ~5ms P99 | Latency-sensitive |
| 500-2000   | Balanced   | ~10ms P99 | General workload |
| 2000-5000  | Higher     | ~25ms P99 | Throughput-focused |

### Compaction Tuning

```yaml
# For write-heavy workloads
config:
  lsm_l0_compaction_trigger: 8       # Delay compaction
  lsm_compaction_threads: 3          # More parallel work
  lsm_disable_partial_compaction: true  # Reduce compaction overhead
```

## Prevention

- **Storage provisioning:** Use NVMe with sufficient IOPS for write rate
- **Compaction headroom:** Tune L0 trigger based on write patterns
- **Batch sizing:** Use appropriate batch sizes for latency requirements
- **Monitoring:** Alert on compaction backlog growth
- **Capacity planning:** Size for peak write rates with headroom

## Verification

After resolution:

```bash
# Verify write latency improved
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_write_latency_seconds

# Verify compaction backlog is decreasing
watch -n 30 'kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_pending_bytes'

# Monitor for 15 minutes
watch -n 30 'kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_write_latency_seconds | grep quantile=\"0.99\"'
```

## Related Documentation

- [Compaction Backlog](compaction-backlog.md) - Compaction-specific guidance
- [LSM Tuning](../lsm-tuning.md) - Storage performance tuning
- [Capacity Planning](../capacity-planning.md) - Sizing guidelines
- [Troubleshooting Guide](../troubleshooting.md#high-latency) - General latency troubleshooting
