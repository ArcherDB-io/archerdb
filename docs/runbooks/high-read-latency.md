# Alert: ArcherDBReadLatencyP99Warning / ArcherDBReadLatencyP99Critical

## Quick Reference
- **Severity:** warning (P99 > 25ms), critical (P99 > 100ms)
- **Metric:** `archerdb_read_latency_seconds`
- **Threshold:** Warning: 25ms (25x baseline), Critical: 100ms (100x baseline)
- **Time to Respond:** Warning: 1 hour, Critical: 15 minutes

## What This Alert Means

Read queries are taking longer than acceptable thresholds. Baseline read latency is approximately 1ms, so these alerts indicate significant degradation:
- **Warning (25ms):** 25x baseline - noticeable impact on application performance
- **Critical (100ms):** 100x baseline - severe degradation requiring immediate investigation

## Immediate Actions

1. [ ] Check for active compaction
2. [ ] Verify disk I/O is not saturated
3. [ ] Check for index degradation (probe limit hits)
4. [ ] Review recent query patterns

## Investigation

### Common Causes

- **Compaction activity:** LSM compaction causes I/O contention
- **Disk saturation:** High write load saturating disk bandwidth
- **Index degradation:** RAM index exceeding capacity (see [Index Degraded](index-degraded.md))
- **Large result sets:** Queries returning excessive data
- **Cache misses:** Block cache not effective for workload

### Diagnostic Commands

```bash
# Check current latency percentiles
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_read_latency_seconds

# Check for active compaction
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction

# Check disk I/O
kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
# Look for %util > 80% or high await times

# Check cache hit rate
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_cache

# Check index health
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_index

# Check query rate
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep 'archerdb_operations_total{.*query'
```

### Log Analysis

```bash
# Look for slow query warnings
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "slow query"

# Check for compaction events
kubectl logs archerdb-0 -n archerdb --since=1h | grep -i "compaction"
```

## Resolution

### Compaction-Induced Latency

1. **Verify compaction is the cause:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_compaction_active
   # Value of 1 indicates active compaction
   ```

2. **Compaction is normal operation.** If frequent, tune compaction settings:
   ```yaml
   # values.yaml - Phase 5 optimized defaults
   config:
     lsm_l0_compaction_trigger: 8  # Delay compaction start
     lsm_compaction_threads: 3     # More parallel threads
   ```

3. **See [LSM Tuning](../lsm-tuning.md) for detailed compaction tuning.**

### Disk Saturation

1. **Check disk utilization:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- iostat -x 1 5
   # %util > 80% indicates saturation
   ```

2. **Resolution options:**
   - Reduce write rate if possible
   - Upgrade to faster storage (NVMe recommended)
   - Increase compaction threads to complete faster

### Index Degradation

1. **Check for probe limit hits:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_index_probe_limit_hits_total
   ```

2. **If counter is increasing,** see [Index Degraded Runbook](index-degraded.md).

### Large Result Sets

1. **Review query patterns:**
   - Check if radius queries are using very large radii
   - Check if polygon queries cover large areas
   - Check if limits are not being used

2. **Add limits to queries:**
   ```python
   # Limit result set size
   results = client.query_radius(
       center_lat=37.7749,
       center_lon=-122.4194,
       radius_m=1000,
       limit=100  # Add reasonable limit
   )
   ```

### Cache Optimization

1. **Check cache effectiveness:**
   ```bash
   kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_cache_hit_ratio
   ```

2. **If hit ratio < 50%,** consider:
   - Increasing block cache size
   - Reviewing query patterns for spatial locality
   - Increasing S2 covering cache (spatial queries)

## Prevention

- **Capacity planning:** Size storage for peak write rates with headroom for compaction
- **Index sizing:** Maintain RAM index at < 50% load factor
- **Query optimization:** Use appropriate limits and narrow spatial queries
- **Monitoring:** Alert on latency trends, not just thresholds
- **Storage tier:** Use NVMe for production workloads

## Verification

After resolution:

```bash
# Verify latency improved
kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_read_latency_seconds

# Check P99 is below threshold
# histogram_quantile(0.99, ...) should be < 0.025 (25ms)

# Monitor for 15 minutes to ensure stability
watch -n 30 'kubectl exec archerdb-0 -n archerdb -- curl -s localhost:9090/metrics | grep archerdb_read_latency_seconds | grep quantile=\"0.99\"'
```

## Related Documentation

- [LSM Tuning](../lsm-tuning.md) - Compaction and storage tuning
- [Index Degraded](index-degraded.md) - RAM index issues
- [Capacity Planning](../capacity-planning.md) - Sizing guidelines
- [Troubleshooting Guide](../troubleshooting.md#high-latency) - General latency troubleshooting
