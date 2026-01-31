# Alert: ArcherDBCompactionBacklog

## Quick Reference
- **Severity:** warning
- **Metric:** `archerdb_compaction_pending_bytes`
- **Threshold:** > 1GB pending compaction
- **Time to Respond:** Within 1 hour

## What This Alert Means

LSM tree compaction is falling behind the write rate. When compaction cannot keep up:
- **Read latency increases** (more levels to search)
- **Write latency may spike** (write stalls when L0 full)
- **Disk usage grows** faster than expected

## Immediate Actions

1. [ ] Check current L0 file count
2. [ ] Verify compaction is running
3. [ ] Check disk I/O capacity
4. [ ] Assess write rate vs compaction throughput

## Investigation

### Common Causes

- **High write rate:** Writes exceeding compaction capacity
- **Under-provisioned disk:** I/O bandwidth insufficient
- **CPU-limited compaction:** Not enough compaction threads
- **Large L0 trigger:** Compaction starting too late

### Diagnostic Commands

```bash
# Check compaction backlog size
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_pending_bytes

# Check L0 file count (trigger point)
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_lsm_level_0_files
# > 8 files means compaction trigger reached

# Check if compaction is active
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_active
# 1 = running, 0 = idle

# Check compaction throughput
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_bytes_written

# Check write rate
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep 'archerdb_bytes_written_total'

# Check disk I/O
kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
```

### Log Analysis

```bash
# Check for compaction events
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "compaction"

# Check for write stalls
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "stall\|pause"
```

## Resolution

### Tune Compaction Settings

Phase 5 optimization established these defaults for write-heavy workloads:

```yaml
# values.yaml
config:
  lsm_l0_compaction_trigger: 8       # Allow 8 L0 files before compaction
  lsm_compaction_threads: 3          # 3 parallel compaction threads
  lsm_disable_partial_compaction: true  # Complete compactions only
```

1. **Increase compaction threads** (if CPU available):
   ```yaml
   lsm_compaction_threads: 4  # Increase from 3
   ```

2. **Adjust L0 trigger** (trade-off: higher = more read amplification):
   ```yaml
   lsm_l0_compaction_trigger: 12  # Allow more L0 buildup
   ```

3. **Apply changes with rolling restart:**
   ```bash
   kubectl rollout restart statefulset/archerdb -n archerdb
   ```

### Reduce Write Rate

If compaction cannot keep up even with tuning:

1. **Temporary relief:** Increase batch submission interval
2. **Defer non-critical writes** during peak hours
3. **Consider rate limiting** at application layer

### Upgrade Storage

If disk I/O is the bottleneck:

1. **Check current I/O utilization:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
   # %util > 80% indicates saturation
   ```

2. **Upgrade to faster storage:**
   - NVMe strongly recommended for production
   - Target: > 100K IOPS for heavy write workloads

### Horizontal Scaling (Sharding)

For sustained high write rates beyond single-node capacity:

1. **Consider adding shards** to distribute write load
2. **Each shard handles a subset of data**
3. See [Sharding Strategy](../operations-runbook.md#sharding-strategy-selection)

## Understanding LSM Compaction

### How Compaction Works

```
Writes -> Memtable -> L0 (immutable) -> L1 -> L2 -> ...

When L0 file count reaches trigger (8 by default):
  - Compaction merges L0 files into L1
  - This continues down levels as needed
  - Older/deleted data is discarded
```

### Compaction Tuning Trade-offs

| Setting | Higher Value | Lower Value |
|---------|-------------|-------------|
| `l0_compaction_trigger` | More write throughput, higher read amp | More compaction, lower read amp |
| `compaction_threads` | Faster compaction, more CPU | Slower compaction, less CPU |

### Write Amplification

Compaction causes write amplification (data written multiple times during compaction):
- Expected: 10-30x write amplification
- If higher, consider tuning or sharding

```bash
# Check write amplification
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_write_amp
```

## Prevention

- **Capacity planning:** Size disk I/O for peak write rate + compaction overhead
- **Monitoring:** Alert when backlog > 500MB (early warning)
- **Tuning:** Establish baseline and tune for your workload
- **Storage tier:** Use NVMe for write-heavy workloads

## Verification

After resolution:

```bash
# Verify backlog is decreasing
watch -n 30 'kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_pending_bytes'

# Verify L0 file count is healthy
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_lsm_level_0_files
# Should be < trigger value

# Verify latency improved
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_write_latency_seconds
```

## Related Documentation

- [LSM Tuning](../lsm-tuning.md) - Detailed compaction tuning guide
- [High Write Latency](high-write-latency.md) - If backlog causes latency alerts
- [Disk Capacity](disk-capacity.md) - If backlog affects disk usage
- [Capacity Planning](../capacity-planning.md) - Sizing guidelines
